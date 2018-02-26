//
//
//  Offer.swift
//
//  Created by Kin Foundation
//  Copyright © 2018 Kin Foundation. All rights reserved.
//
//  kinecosystem.org
//

import Foundation
import CoreData

enum OfferType: String {
    case earn
    case spend
}

enum OfferContentType: String {
    case poll
    case coupon
}

class OffersList: EntityPresentor {
    typealias entity = Offer
    var offers: [entity]
    var entities: [entity] {
        return offers
    }
}

class Offer: NSManagedObject, NetworkSyncable {

    @NSManaged public var amount: Int32
    @NSManaged public var description_: String
    @NSManaged public var id: String
    @NSManaged public var image: String
    @NSManaged public var offer_type: String
    @NSManaged public var content_type: String
    @NSManaged public var content: String
    @NSManaged public var title: String
    
    var offerType: OfferType {
        get { return OfferType(rawValue: offer_type)! }
        set { offer_type = newValue.rawValue }
    }
    
    var offerContentType: OfferContentType {
        get { return OfferContentType(rawValue: content_type)! }
        set { content_type = newValue.rawValue }
    }
    
    enum OfferKeys: String, CodingKey {
        case amount
        case description
        case id
        case image
        case offer_type
        case title
        case content
        case content_type
    }
    
    required convenience public init(from decoder: Decoder) throws {
        guard let managedObjectContext = decoder.userInfo[.context] as? NSManagedObjectContext,
            let entity = NSEntityDescription.entity(forEntityName: "Offer", in: managedObjectContext) else {
                fatalError()
        }
        
        self.init(entity: entity, insertInto: nil)
        let values = try decoder.container(keyedBy: OfferKeys.self)
        
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        description_ = try values.decode(String.self, forKey: .description)
        image = try values.decode(String.self, forKey: .image)
        amount = try values.decode(Int32.self, forKey: .amount)
        offer_type = try values.decode(String.self, forKey: .offer_type)
        content_type = try values.decode(String.self, forKey: .content_type)
        content = try values.decode(String.self, forKey: .content)
    }
    
    var syncId: String {
        return id
    }
    
    func update(_ from: Offer) {
        amount = from.amount
        description_ = from.description_
        offer_type = from.offer_type
        image = from.image
        title = from.title
        content_type = from.content_type
        content =  from.content
    }
    
}






